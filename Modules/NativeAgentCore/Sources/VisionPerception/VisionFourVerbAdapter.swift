import CoreGraphics
import Foundation
import ImageIO
import MacControl

/// Decode the screenshot bytes owned by the fused Mac view without teaching
/// ChatOrchestration about ImageIO.
public enum VisionImageDecoder {
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

public struct VisionImageCrop {
    public let image: CGImage
    public let origin: (x: Double, y: Double)
    public let logicalSize: (width: Double, height: Double)
}

private struct VisionLinearIndicatorRender {
    let values: [MacScreenRender.Value]
    let claimedReadoutHandles: Set<String>
    let claimedRecognizedKeys: Set<String>
}

private struct VisionSpatialNode {
    let id: Int
    let color: String?
    let shape: String?
    let rect: VisionRect
    let confidence: Double
}

/// Focus the expensive pixel compiler on the visual surface AX located while
/// preserving the same global hand coordinate space. Saliency over an entire
/// browser window naturally prefers tabs and badges; saliency over the page's
/// canvas describes the world the agent is actually trying to manipulate.
public enum VisionImageCropper {
    public static func crop(
        _ image: CGImage,
        to globalFrame: MacAXFrame?,
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double)
    ) -> VisionImageCrop {
        guard let globalFrame,
              logicalSize.width > 0,
              logicalSize.height > 0 else {
            return VisionImageCrop(image: image, origin: origin, logicalSize: logicalSize)
        }
        let scaleX = Double(image.width) / logicalSize.width
        let scaleY = Double(image.height) / logicalSize.height
        let requested = CGRect(
            x: (globalFrame.x - origin.x) * scaleX,
            y: (globalFrame.y - origin.y) * scaleY,
            width: globalFrame.w * scaleX,
            height: globalFrame.h * scaleY
        ).integral
        let available = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = requested.intersection(available)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let cropped = image.cropping(to: clipped) else {
            return VisionImageCrop(image: image, origin: origin, logicalSize: logicalSize)
        }
        let cropOrigin = (
            x: origin.x + clipped.minX / scaleX,
            y: origin.y + clipped.minY / scaleY
        )
        let cropSize = (
            width: clipped.width / scaleX,
            height: clipped.height / scaleY
        )
        return VisionImageCrop(image: cropped, origin: cropOrigin, logicalSize: cropSize)
    }
}

/// The persistent identity and temporal state assigned by the live semantic
/// screen. It is additive evidence: the vision compiler still owns what a
/// region is, while the live scene owns whether this is the same region seen
/// on the prior observation and how it moved.
public struct VisionLiveRegionIdentity: Sendable, Equatable {
    public let id: Int
    public let motion: String?
    /// A bounded lead, in global logical points, derived from consecutive
    /// captured frames. It moves only the private motor target; the rendered
    /// scene continues to describe the object where it was actually observed.
    public let projectedX: Double
    public let projectedY: Double
    /// The measured direction is readable, but latency-sized motor lead still
    /// needs another frame. Consumed by the existing bounded act acquisition.
    public let needsMotionConfirmation: Bool

    public init(
        id: Int,
        motion: String? = nil,
        projectedX: Double = 0,
        projectedY: Double = 0,
        needsMotionConfirmation: Bool = false
    ) {
        self.id = id
        self.motion = motion
        self.projectedX = projectedX
        self.projectedY = projectedY
        self.needsMotionConfirmation = needsMotionConfirmation
    }
}

public struct VisionLiveOccludedRegion: Sendable, Equatable {
    public let id: Int
    public let colorName: String?
    public let shapeName: String?
    public let lastCenterXPercent: Int
    public let lastCenterYPercent: Int
    public let expectedCenterXPercent: Int?
    public let expectedCenterYPercent: Int?
    public let missedFrames: Int
    public let confidence: Double

    public init(
        id: Int,
        colorName: String?,
        shapeName: String? = nil,
        lastCenterXPercent: Int,
        lastCenterYPercent: Int,
        expectedCenterXPercent: Int? = nil,
        expectedCenterYPercent: Int? = nil,
        missedFrames: Int,
        confidence: Double
    ) {
        self.id = id
        self.colorName = colorName
        self.shapeName = shapeName
        self.lastCenterXPercent = lastCenterXPercent
        self.lastCenterYPercent = lastCenterYPercent
        self.expectedCenterXPercent = expectedCenterXPercent
        self.expectedCenterYPercent = expectedCenterYPercent
        self.missedFrames = missedFrames
        self.confidence = confidence
    }
}

extension VisionPercept {
    /// Translate pixel evidence into the same additive screen/target contract
    /// the AX lane uses. Confidence is not decoration: uncertain, overlapping,
    /// or destructive-looking rows remain visible with an abstain reason but
    /// do not become act targets.
    public func fourVerbSupplement(
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double),
        viewId: String? = nil,
        globalRegionOfInterest: MacAXFrame? = nil,
        liveRegionIdentities: [VisionRect: VisionLiveRegionIdentity] = [:],
        liveOccludedRegions: [VisionLiveOccludedRegion] = []
    ) -> MacFourVerbsSupplement {
        let scaleX = frameSize.width > 0 ? logicalSize.width / frameSize.width : 1
        let scaleY = frameSize.height > 0 ? logicalSize.height / frameSize.height : 1
        func global(_ rect: VisionRect) -> MacAXFrame {
            MacAXFrame(
                x: origin.x + rect.x * scaleX,
                y: origin.y + rect.y * scaleY,
                w: rect.w * scaleX,
                h: rect.h * scaleY
            )
        }
        func screenText(_ label: VisionRedactedText?) -> MacScreenText? {
            guard let label else { return nil }
            return MacScreenText(label.raw, redacted: label.json)
        }
        func abstainReason(_ row: VisionAffordanceRow) -> String? {
            if let ambiguous = row.ambiguous { return ambiguous }
            if row.destructiveRisk { return "destructive-looking pixel target needs semantic confirmation" }
            if row.confidence.bounds < 0.55 { return "bounds confidence below physical-action floor" }
            if row.confidence.target < 0.55 { return "target confidence below physical-action floor" }
            return nil
        }

        var contentRows: [MacScreenRender.Row] = []
        var controls: [MacScreenRender.Control] = []
        var targets: [MacFourVerbsSupplementalTarget] = []
        var rowOrdinal = 0
        var unnamedOrdinalByKind: [String: Int] = [:]
        var visualRegionOrdinal = 0
        var summarizedFragments: [String: Int] = [:]
        var summarizedFragmentConfidence = 0.0
        func insideRegionOfInterest(_ rect: VisionRect) -> Bool {
            guard let globalRegionOfInterest else { return true }
            let translated = global(rect)
            let centerX = translated.x + translated.w / 2
            let centerY = translated.y + translated.h / 2
            return centerX >= globalRegionOfInterest.x
                && centerX <= globalRegionOfInterest.x + globalRegionOfInterest.w
                && centerY >= globalRegionOfInterest.y
                && centerY <= globalRegionOfInterest.y + globalRegionOfInterest.h
        }
        let perceivedRows = rows.filter { insideRegionOfInterest($0.rect) }
        let redundantHaloIndexes = Self.redundantColorlessHaloIndexes(
            in: perceivedRows, frameSize: frameSize
        )
        let redundantSameColorIndexes = Self.redundantSameColorRegionIndexes(
            in: perceivedRows, frameSize: frameSize
        )
        let redundantVisualIndexes = redundantHaloIndexes.union(redundantSameColorIndexes)
        let linearIndicatorIndexes = Self.linearIndicatorIndexes(
            in: perceivedRows, frameSize: frameSize
        )
        let indicatorRender = Self.linearIndicatorValues(
            in: perceivedRows,
            indexes: linearIndicatorIndexes,
            frameSize: frameSize,
            readouts: readouts,
            recognizedText: recognizedText
        )

        // A pixel compiler can find dozens of decorative fragments. Publish a
        // small ranked physical vocabulary, not a wall of coordinate aliases.
        let spatialIndexes = Set(perceivedRows.enumerated()
            .filter {
                !redundantVisualIndexes.contains($0.offset)
                    && !linearIndicatorIndexes.contains($0.offset)
                    && Self.isPhysicalRegionCandidate($0.element, frameSize: frameSize)
            }
            .sorted { lhs, rhs in
                let left = lhs.element.salience * 3
                    + (lhs.element.visualContrast ?? 0) * 2
                    + min(1, lhs.element.rect.area / max(1, frameSize.width * frameSize.height) * 20)
                let right = rhs.element.salience * 3
                    + (rhs.element.visualContrast ?? 0) * 2
                    + min(1, rhs.element.rect.area / max(1, frameSize.width * frameSize.height) * 20)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .prefix(8)
            .map(\.offset))

        for (rowIndex, row) in perceivedRows.enumerated() {
            if redundantVisualIndexes.contains(rowIndex) { continue }
            if linearIndicatorIndexes.contains(rowIndex) {
                continue
            }
            let kind = MacScreenRender.kindName(role: row.roleGuess)
            // OCR occasionally binds a lone list/detection marker to an
            // otherwise uncertain visual fragment. The same glyph is already
            // rejected from readouts and recognized-text values; do not let a
            // row-label path resurrect it as an apparent object.
            let labelText: MacScreenText? = {
                guard let label = screenText(row.label) else { return nil }
                guard let display = label.display,
                      !Self.isStandaloneOCRNoise(display) else { return nil }
                return label
            }()
            let reason = abstainReason(row)
            // Saliency can pin a bounded, prominent place while honestly
            // knowing nothing about its semantic role. Publish that place as
            // a numbered physical region, never as an invented button.
            let spatiallyAddressable = reason != nil && spatialIndexes.contains(rowIndex)
            let renderedConfidence = spatiallyAddressable
                ? Self.physicalPointConfidence(row)
                : row.confidence.target
            // A substantial muted region can be valuable scene/tracking
            // evidence before it is reliable enough to aim at. Keep the
            // numbered object visible, but require the same confidence floor
            // used by short occlusion memory before publishing a motor target.
            let motorAddressable = spatiallyAddressable && renderedConfidence >= 0.25
            let spatialLabel: MacScreenText? = {
                guard spatiallyAddressable else { return nil }
                let identity = liveRegionIdentities[row.rect]
                let number: Int
                if let identity {
                    number = identity.id
                } else {
                    visualRegionOrdinal += 1
                    number = visualRegionOrdinal
                }
                let label = "visual region \(number)"
                return MacScreenText(label, redacted: .string(label))
            }()
            let renderedLabel = labelText ?? spatialLabel
            let spatialDescription: [MacScreenText] = {
                guard spatiallyAddressable else { return [] }
                let horizontal = row.rect.centerX < frameSize.width / 3 ? "left"
                    : row.rect.centerX > frameSize.width * 2 / 3 ? "right" : "center"
                let vertical = row.rect.centerY < frameSize.height / 3 ? "upper"
                    : row.rect.centerY > frameSize.height * 2 / 3 ? "lower" : "middle"
                let contrast = row.visualContrast ?? 0
                let prominence = contrast >= 0.45 ? "high contrast"
                    : contrast >= 0.25 ? "visible contrast" : "low contrast"
                let motion = liveRegionIdentities[row.rect]?.motion
                let color = row.visualColor.map { "\($0), " } ?? ""
                func percent(_ value: Double, of total: Double) -> Int {
                    guard total > 0 else { return 0 }
                    return min(100, max(0, Int((value / total * 100).rounded())))
                }
                let centerX = percent(row.rect.centerX, of: frameSize.width)
                let centerY = percent(row.rect.centerY, of: frameSize.height)
                let width = max(1, percent(row.rect.w, of: frameSize.width))
                let height = max(1, percent(row.rect.h, of: frameSize.height))
                let geometry = "at \(centerX)%,\(centerY)%, size \(width)%x\(height)%"
                // Each fact gets its own bounded slot. One long description
                // lost geometry and motion under the ordinary40-character cap.
                let facts = ["\(color)\(prominence)", "\(vertical) \(horizontal)", geometry]
                    + (motion.map { [$0] } ?? [])
                return facts.map { MacScreenText($0, redacted: .string($0)) }
            }()
            // A spatial fallback is a region even when the role guess says
            // checkbox/button. Rendering that uncertain guess as a control
            // both invents semantics and pushes the region behind rich AX
            // chrome under the control cap.
            let isControl = !spatiallyAddressable
                && MacPerceptionCompiler.controlRoles.contains(row.roleGuess)
            if isControl {
                controls.append(MacScreenRender.Control(
                    label: renderedLabel ?? MacScreenText("unnamed \(kind)", redacted: .string("unnamed \(kind)")),
                    kind: kind,
                    states: reason == nil ? [] : (spatiallyAddressable ? ["spatial", "role uncertain"] : ["uncertain"]),
                    provenance: .vision(renderedConfidence),
                    abstain: spatiallyAddressable ? nil : reason
                ))
            } else {
                if renderedLabel == nil, !spatiallyAddressable, let reason {
                    let category: String
                    if reason.contains("overlapping") { category = "overlapping" }
                    else if reason.contains("bounds confidence") { category = "low bounds confidence" }
                    else if reason.contains("target confidence") { category = "low target confidence" }
                    else if reason.contains("unlabeled") { category = "unlabeled" }
                    else { category = "other uncertainty" }
                    summarizedFragments[category, default: 0] += 1
                    summarizedFragmentConfidence = max(summarizedFragmentConfidence, row.confidence.target)
                    continue
                }
                rowOrdinal += 1
                let aspect = row.rect.h > 0 ? row.rect.w / row.rect.h : 1
                let physicalShape = row.visualShape ?? (aspect <= 0.70 ? "tall"
                    : aspect >= 1.45 ? "wide" : "compact")
                let physicalKind = spatiallyAddressable
                    ? "\(physicalShape) physical object" : kind
                contentRows.append(MacScreenRender.Row(
                    label: renderedLabel,
                    detail: [MacScreenText(physicalKind, redacted: .string(physicalKind))]
                        + spatialDescription,
                    provenance: .vision(renderedConfidence),
                    abstain: motorAddressable ? nil : (spatiallyAddressable
                        ? "physical point confidence too low; observe again" : reason),
                    physicalOnly: motorAddressable
                ))
            }

            guard reason == nil || motorAddressable else { continue }
            let ordinal: Int? = isControl ? nil : rowOrdinal
            let targetLabel: MacScreenText = {
                if let renderedLabel { return renderedLabel }
                let number = (unnamedOrdinalByKind[kind] ?? 0) + 1
                unnamedOrdinalByKind[kind] = number
                let synthetic = "visual \(kind) \(number)"
                return MacScreenText(synthetic, redacted: .string(synthetic))
            }()
            let appearanceAliases: [String] = {
                guard spatiallyAddressable else { return [] }
                var aliases: [String]
                switch (row.visualShape, row.visualColor) {
                case let (shape?, color?):
                    aliases = [
                        "\(shape) \(color) object",
                        "\(color) \(shape) object",
                        "\(color) object",
                    ]
                case let (nil, color?):
                    aliases = ["\(color) object"]
                case let (shape?, nil):
                    aliases = ["\(shape) object"]
                case (nil, nil):
                    aliases = []
                }
                let base = aliases.last
                // Publish the same measured silhouette in ordinary noun form.
                // "green square" must address the square she just saw without
                // requiring the internal phrase "square green object".
                // Unknown silhouettes get no invented shape name.
                let naturalBases = Self.naturalShapeNames(row)
                aliases.append(contentsOf: naturalBases)
                let horizontal = row.rect.centerX < frameSize.width / 3 ? "left"
                    : row.rect.centerX > frameSize.width * 2 / 3 ? "right" : "center"
                let vertical = row.rect.centerY < frameSize.height / 3 ? "upper"
                    : row.rect.centerY > frameSize.height * 2 / 3 ? "lower" : "middle"
                for spatialBase in [base].compactMap({ $0 }) + naturalBases {
                    aliases.append("\(horizontal) \(spatialBase)")
                    aliases.append("\(vertical) \(spatialBase)")
                    aliases.append("\(spatialBase) at \(vertical) \(horizontal)")
                    if horizontal != "center" {
                        aliases.append("\(spatialBase) on the \(horizontal)")
                    }
                }
                let temporalBases = Array(Set([base, aliases.first].compactMap { $0 } + naturalBases)).sorted()
                if let motion = liveRegionIdentities[row.rect]?.motion,
                   motion.hasPrefix("moving ") {
                    aliases.append("moving object")
                    if let shape = row.visualShape {
                        aliases.append("moving \(shape) object")
                    }
                    for temporalBase in temporalBases {
                        aliases.append("moving \(temporalBase)")
                        aliases.append("\(motion) \(temporalBase)")
                        aliases.append("\(temporalBase) \(motion)")
                    }
                } else if liveRegionIdentities[row.rect]?.motion == "stationary" {
                    aliases.append("stationary object")
                    if let shape = row.visualShape {
                        aliases.append("stationary \(shape) object")
                    }
                    for temporalBase in temporalBases {
                        aliases.append("stationary \(temporalBase)")
                        aliases.append("\(temporalBase) stationary")
                    }
                }
                let nearest = spatialIndexes
                    .filter { $0 != rowIndex && liveRegionIdentities[perceivedRows[$0].rect] != nil }
                    .compactMap { index -> (row: VisionAffordanceRow, distance: Double)? in
                        let other = perceivedRows[index]
                        guard other.visualColor != nil || other.visualShape != nil else { return nil }
                        let dx = (other.rect.centerX - row.rect.centerX) / max(1, frameSize.width)
                        let dy = (other.rect.centerY - row.rect.centerY) / max(1, frameSize.height)
                        return (other, hypot(dx, dy))
                    }
                    .min { $0.distance < $1.distance }?.row
                if let base, let nearest {
                    let dx = nearest.rect.centerX - row.rect.centerX
                    let dy = nearest.rect.centerY - row.rect.centerY
                    let overlaps = row.rect.iou(nearest.rect) >= 0.05
                        || row.rect.coverage(by: nearest.rect) >= 0.15
                        || nearest.rect.coverage(by: row.rect) >= 0.15
                    let relation = overlaps ? "overlapping"
                        : abs(dx) >= abs(dy) ? (dx >= 0 ? "left of" : "right of")
                        : (dy >= 0 ? "above" : "below")
                    let otherBase = nearest.visualColor.map { "\($0) object" }
                        ?? nearest.visualShape.map { "\($0) object" }
                    if let otherBase {
                        // The same measured relation must accept the natural
                        // shape nouns published for both participants. These
                        // stay private aliases; no new relation is inferred.
                        for subject in [base] + naturalBases {
                            for object in [otherBase] + Self.naturalShapeNames(nearest) {
                                aliases.append("\(subject) \(relation) \(object)")
                            }
                        }
                    }
                }
                return aliases
            }()
            targets.append(MacFourVerbsSupplementalTarget(
                label: targetLabel,
                aliases: appearanceAliases,
                kind: spatiallyAddressable ? "visual region" : kind,
                frame: {
                    let observed = global(row.rect)
                    guard spatiallyAddressable,
                          let identity = liveRegionIdentities[row.rect] else { return observed }
                    return MacAXFrame(
                        x: min(
                            max(origin.x, observed.x + identity.projectedX),
                            origin.x + logicalSize.width - observed.w
                        ),
                        y: min(
                            max(origin.y, observed.y + identity.projectedY),
                            origin.y + logicalSize.height - observed.h
                        ),
                        w: observed.w,
                        h: observed.h
                    )
                }(),
                observedFrame: global(row.rect),
                provenance: .vision(renderedConfidence),
                viewId: viewId,
                ordinal: ordinal,
                physicalOnly: motorAddressable,
                motionUncertain: motorAddressable
                    && (liveRegionIdentities[row.rect]?.needsMotionConfirmation == true
                        || (liveRegionIdentities[row.rect]?.motion != "stationary"
                            && liveRegionIdentities[row.rect]?.motion?.hasPrefix("moving ") != true))
            ))
        }

        let summarizedCount = summarizedFragments.values.reduce(0, +)
        if summarizedCount > 0 {
            let categories = summarizedFragments.keys.sorted().map {
                "\(summarizedFragments[$0] ?? 0) \($0)"
            }.joined(separator: ", ")
            let label = "\(summarizedCount) uncertain visual fragment"
                + (summarizedCount == 1 ? "" : "s")
            contentRows.append(MacScreenRender.Row(
                label: MacScreenText(label, redacted: .string(label)),
                detail: [MacScreenText("not separately addressable", redacted: .string("not separately addressable"))],
                provenance: .vision(summarizedFragmentConfidence),
                abstain: "summarized non-addressable regions: \(categories)"
            ))
        }

        var contents: [MacScreenRender.Content] = []
        if !contentRows.isEmpty {
            contents.append(MacScreenRender.Content(
                kind: .grid,
                rows: contentRows,
                totalRows: contentRows.count + abstain.droppedBeyondCap,
                scrollable: true
            ))
        }
        // The captured image's own extent is exact even when OCR finds no
        // rows—the common canvas/game/video case. Row confidence describes
        // objects inside it, not whether the visual surface itself exists.
        let canvasConfidence = 1.0
        let fullCanvasRect = VisionRect(x: 0, y: 0, w: frameSize.width, h: frameSize.height)
        let canvasFrame = globalRegionOfInterest ?? global(fullCanvasRect)
        contents.append(MacScreenRender.Content(
            kind: .canvas,
            canvas: MacScreenRender.Canvas(
                description: "visual surface",
                width: canvasFrame.w,
                height: canvasFrame.h,
                provenance: .vision(canvasConfidence),
                hasPerceptualEvidence: !rows.isEmpty || !recognizedText.isEmpty || !readouts.isEmpty,
                hasRegionTarget: canvasFrame.w > 0 && canvasFrame.h > 0
            )
        ))
        if canvasConfidence >= 0.55, canvasFrame.w > 0, canvasFrame.h > 0 {
            targets.append(MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual surface", redacted: .string("visual surface")),
                aliases: ["canvas", "viewport", "world"],
                kind: "canvas",
                frame: canvasFrame,
                provenance: .vision(canvasConfidence),
                viewId: viewId,
                regionOnly: true
            ))
        }

        var values = indicatorRender.values + readouts.filter {
            insideRegionOfInterest($0.rect)
                && !indicatorRender.claimedReadoutHandles.contains($0.handle)
                && !($0.text.display.map(Self.isStandaloneOCRNoise) ?? false)
        }.map {
            MacScreenRender.Value(
                text: MacScreenText($0.text.raw, redacted: $0.text.json),
                provenance: .vision($0.confidence.text)
            )
        }
        // The affordance compiler intentionally promotes only one contained
        // string to a row label and reserves standalone readouts for prominent
        // text. A canvas HUD needs neither filter: every recognized, already-
        // redacted string is something the screen SAYS. Publish the bounded
        // set here so counters such as Hits/Misses cannot disappear merely
        // because a larger title shares their text band.
        var valueKeys = Set(values.compactMap { $0.text.display?.lowercased() })
        for recognized in recognizedText {
            guard values.count < 16,
                  let label = screenText(recognized.text),
                  let display = label.display else { continue }
            let key = display.lowercased()
            guard !valueKeys.contains(key),
                  !indicatorRender.claimedRecognizedKeys.contains(key),
                  !Self.isStandaloneOCRNoise(display) else { continue }
            valueKeys.insert(key)
            values.append(MacScreenRender.Value(
                text: label,
                provenance: .vision(recognized.confidence)
            ))
        }
        // Only HUD/readout/OCR values may prove that an action had a visible
        // effect. Occlusion memory and scene relations naturally change while
        // objects move, even when an input did nothing.
        let effectValueTexts = values.compactMap(\.text.display)
        for occluded in liveOccludedRegions.prefix(max(0, 16 - values.count)) {
            let appearance = [occluded.shapeName, occluded.colorName]
                .compactMap { $0 }
                .joined(separator: " ")
            let prefix = appearance.isEmpty ? "" : "\(appearance) "
            let frameWord = occluded.missedFrames == 1 ? "frame" : "frames"
            var text = "\(prefix)visual region \(occluded.id) temporarily not visible; last seen at \(occluded.lastCenterXPercent)%,\(occluded.lastCenterYPercent)% (\(occluded.missedFrames) \(frameWord) ago)"
            if let x = occluded.expectedCenterXPercent,
               let y = occluded.expectedCenterYPercent {
                text += "; expected near \(x)%,\(y)% if motion continued"
            }
            values.append(MacScreenRender.Value(
                text: MacScreenText(text, redacted: .string(text)),
                provenance: .vision(occluded.confidence)
            ))
        }
        let spatialValues = Self.spatialRelationValues(
            in: perceivedRows,
            indexes: spatialIndexes,
            frameSize: frameSize,
            identities: liveRegionIdentities
        )
        values.append(contentsOf: spatialValues.prefix(max(0, 16 - values.count)))
        return MacFourVerbsSupplement(
            contents: contents,
            controls: controls,
            values: values,
            targets: targets,
            diagnostics: [
                "vision_effect_value_text": .array(effectValueTexts.map { .string($0) })
            ]
        )
    }

    /// One shared physical-region admission rule for both the live tracker and
    /// the screen adapter. Tracking a decorative fragment the adapter will
    /// never publish would consume stable ids and make the agent's screen feel
    /// discontinuous even though the same compiler produced both views.
    public static func isPhysicalRegionCandidate(
        _ row: VisionAffordanceRow,
        frameSize: VisionSize? = nil
    ) -> Bool {
        let roleUnknown = row.ambiguous == nil
            || row.ambiguous?.contains("unlabeled region with no role guess") == true
        guard row.displayLabel == nil, roleUnknown, !row.destructiveRisk else { return false }
        let saliencyAreaIsTargetSized: Bool = {
            guard let frameSize else { return true }
            let frameArea = frameSize.width * frameSize.height
            return frameArea > 0 && row.rect.area / frameArea <= 0.12
        }()
        let salient = row.evidence.contains(.saliency)
            && row.confidence.bounds >= 0.30
            && row.salience >= 0.45
            && saliencyAreaIsTargetSized
        let boundedColor = row.evidence.contains(.colorRegion)
            && row.confidence.bounds >= 0.82
            && {
                let contrast = row.visualContrast ?? 0
                guard contrast < 0.25 else { return true }
                guard contrast >= 0.10, let frameSize else { return false }
                let frameArea = frameSize.width * frameSize.height
                // A substantial, crisply bounded low-contrast region may be
                // an obstacle or scene object. Tiny muted fragments remain
                // below the motor vocabulary floor.
                return frameArea > 0 && row.rect.area / frameArea >= 0.001
            }()
        return salient || boundedColor
    }

    /// A soft attention blob and a precise coloured core can be two detector
    /// views of one object. Suppress only the colorless saliency-only member,
    /// and only when a strongly bounded colour region is centre-near and of a
    /// comparable scale. The precise row remains as the single visible and
    /// tracked object; a broad panel or distant object cannot satisfy this.
    public static func redundantColorlessHaloIndexes(
        in rows: [VisionAffordanceRow],
        frameSize: VisionSize? = nil
    ) -> Set<Int> {
        var redundant: Set<Int> = []
        for (index, row) in rows.enumerated() {
            guard row.visualColor == nil,
                  row.evidence == [.saliency],
                  Self.isPhysicalRegionCandidate(row, frameSize: frameSize),
                  row.rect.area > 0 else { continue }
            let duplicate = rows.enumerated().contains { otherIndex, other in
                guard otherIndex != index,
                      other.visualColor != nil,
                      other.evidence.contains(.colorRegion),
                      other.confidence.bounds >= 0.75,
                      Self.isPhysicalRegionCandidate(other, frameSize: frameSize),
                      other.rect.area > 0 else { return false }
                let dx = row.rect.centerX - other.rect.centerX
                let dy = row.rect.centerY - other.rect.centerY
                let distance = hypot(dx, dy)
                let reach = max(48, max(other.rect.w, other.rect.h) * 1.5)
                let areaRatio = max(row.rect.area, other.rect.area)
                    / min(row.rect.area, other.rect.area)
                return distance <= reach && areaRatio <= 25
            }
            if duplicate { redundant.insert(index) }
        }
        return redundant
    }

    /// Two strongly overlapping, same-colour physical rows are detector views
    /// of one visible object, not two scene identities. Keep the better pinned
    /// row. Merely nearby same-colour objects remain separate.
    public static func redundantSameColorRegionIndexes(
        in rows: [VisionAffordanceRow],
        frameSize: VisionSize? = nil
    ) -> Set<Int> {
        var redundant: Set<Int> = []
        for leftIndex in rows.indices {
            guard !redundant.contains(leftIndex),
                  let color = rows[leftIndex].visualColor,
                  Self.isPhysicalRegionCandidate(rows[leftIndex], frameSize: frameSize),
                  rows[leftIndex].rect.area > 0 else { continue }
            for rightIndex in rows.indices where rightIndex > leftIndex {
                guard !redundant.contains(rightIndex),
                      rows[rightIndex].visualColor == color,
                      Self.isPhysicalRegionCandidate(rows[rightIndex], frameSize: frameSize),
                      rows[rightIndex].rect.area > 0 else { continue }
                let left = rows[leftIndex]
                let right = rows[rightIndex]
                let dx = left.rect.centerX - right.rect.centerX
                let dy = left.rect.centerY - right.rect.centerY
                let distance = hypot(dx, dy)
                let largestDimension = max(
                    max(left.rect.w, left.rect.h),
                    max(right.rect.w, right.rect.h)
                )
                let areaRatio = max(left.rect.area, right.rect.area)
                    / min(left.rect.area, right.rect.area)
                let duplicate = left.rect.iou(right.rect) >= 0.35
                    || (distance <= largestDimension * 0.25 && areaRatio <= 1.75)
                guard duplicate else { continue }
                func score(_ row: VisionAffordanceRow) -> Double {
                    row.confidence.bounds * 2
                        + (row.visualContrast ?? 0)
                        + row.salience
                }
                if score(right) > score(left) {
                    redundant.insert(leftIndex)
                    break
                } else {
                    redundant.insert(rightIndex)
                }
            }
        }
        return redundant
    }

    /// Extreme, strongly bounded colour strips are status/scene indicators,
    /// not point targets. This is shape evidence only: it does not claim the
    /// bar is health, progress, or any other domain meaning.
    public static func linearIndicatorIndexes(
        in rows: [VisionAffordanceRow],
        frameSize: VisionSize
    ) -> Set<Int> {
        let frameArea = frameSize.width * frameSize.height
        guard frameArea > 0 else { return [] }
        return Set(rows.enumerated().compactMap { index, row in
            guard row.visualColor != nil,
                  row.evidence.contains(.colorRegion),
                  row.confidence.bounds >= 0.75,
                  row.rect.w > 0,
                  row.rect.h > 0 else { return nil }
            let long = max(row.rect.w, row.rect.h)
            let short = min(row.rect.w, row.rect.h)
            let longTotal = row.rect.w >= row.rect.h ? frameSize.width : frameSize.height
            let shortTotal = row.rect.w >= row.rect.h ? frameSize.height : frameSize.width
            guard long / short >= 5,
                  short / shortTotal <= 0.025,
                  long / longTotal <= 0.60 else { return nil }
            return index
        })
    }

    /// Join touching, aligned colour strips before rendering them. Pixel
    /// segmentation commonly returns the filled and remaining portions of one
    /// bar separately; their shared geometry is enough to expose proportions
    /// without guessing what the bar means.
    fileprivate static func linearIndicatorValues(
        in rows: [VisionAffordanceRow],
        indexes: Set<Int>,
        frameSize: VisionSize,
        readouts: [VisionReadoutRow],
        recognizedText: [VisionRecognizedText]
    ) -> VisionLinearIndicatorRender {
        var remaining = indexes
        var groups: [[Int]] = []
        while let seed = remaining.first {
            remaining.remove(seed)
            var group = [seed]
            var expanded = true
            while expanded {
                expanded = false
                for candidate in remaining {
                    let joins = group.contains { member in
                        let left = rows[member].rect
                        let right = rows[candidate].rect
                        let horizontal = left.w >= left.h
                        guard horizontal == (right.w >= right.h) else { return false }
                        let crossDistance = horizontal
                            ? abs(left.centerY - right.centerY)
                            : abs(left.centerX - right.centerX)
                        let crossSize = horizontal
                            ? max(left.h, right.h)
                            : max(left.w, right.w)
                        let leftEnd = horizontal ? left.x + left.w : left.y + left.h
                        let rightStart = horizontal ? right.x : right.y
                        let rightEnd = horizontal ? right.x + right.w : right.y + right.h
                        let leftStart = horizontal ? left.x : left.y
                        let gap = max(0, max(rightStart - leftEnd, leftStart - rightEnd))
                        return crossDistance <= crossSize && gap <= max(4, crossSize * 2)
                    }
                    if joins {
                        group.append(candidate)
                        remaining.remove(candidate)
                        expanded = true
                        break
                    }
                }
            }
            groups.append(group)
        }

        var values: [MacScreenRender.Value] = []
        var claimedReadoutHandles: Set<String> = []
        var claimedRecognizedKeys: Set<String> = []
        for group in groups {
            let horizontal = rows[group[0]].rect.w >= rows[group[0]].rect.h
            let ordered = group.sorted {
                horizontal ? rows[$0].rect.x < rows[$1].rect.x : rows[$0].rect.y < rows[$1].rect.y
            }
            let minX = ordered.map { rows[$0].rect.x }.min() ?? 0
            let minY = ordered.map { rows[$0].rect.y }.min() ?? 0
            let maxX = ordered.map { rows[$0].rect.x + rows[$0].rect.w }.max() ?? 0
            let maxY = ordered.map { rows[$0].rect.y + rows[$0].rect.h }.max() ?? 0
            let totalLength = horizontal ? maxX - minX : maxY - minY
            let centerX = frameSize.width > 0
                ? Int(((minX + maxX) / 2 / frameSize.width * 100).rounded()) : 0
            let centerY = frameSize.height > 0
                ? Int(((minY + maxY) / 2 / frameSize.height * 100).rounded()) : 0
            let longTotal = horizontal ? frameSize.width : frameSize.height
            let length = longTotal > 0
                ? max(1, Int((totalLength / longTotal * 100).rounded())) : 0
            let prefix: String
            var segmentProportions: [Int] = []
            if ordered.count == 1 {
                let color = rows[ordered[0]].visualColor.map { "\($0) " } ?? ""
                prefix = color + (horizontal ? "horizontal" : "vertical") + " indicator"
            } else {
                let segments = ordered.map { index -> String in
                    let row = rows[index]
                    let segmentLength = horizontal ? row.rect.w : row.rect.h
                    let proportion = totalLength > 0
                        ? Int((segmentLength / totalLength * 100).rounded()) : 0
                    segmentProportions.append(proportion)
                    return "\(row.visualColor ?? "unknown") \(proportion)%"
                }.joined(separator: ", ")
                prefix = (horizontal ? "horizontal" : "vertical")
                    + " segmented indicator (\(segments))"
            }
            let geometry = "\(prefix) at \(centerX)%,\(centerY)%, length \(length)%"
            func closeEnough(_ rect: VisionRect) -> Bool {
                let horizontalGap = max(0, max(minX - rect.maxX, rect.x - maxX))
                let verticalGap = max(0, max(minY - rect.maxY, rect.y - maxY))
                return hypot(horizontalGap, verticalGap) <= max(80, totalLength * 0.5)
            }
            let nearbyReadout: VisionReadoutRow? = ordered.count > 1
                ? readouts.filter { readout in
                    guard !claimedReadoutHandles.contains(readout.handle),
                          let display = readout.text.display,
                          let percent = Self.visiblePercent(in: display),
                          segmentProportions.contains(where: { abs($0 - percent) <= 3 }) else {
                        return false
                    }
                    return closeEnough(readout.rect)
                }.min { lhs, rhs in
                    let left = hypot(lhs.rect.centerX - (minX + maxX) / 2,
                                     lhs.rect.centerY - (minY + maxY) / 2)
                    let right = hypot(rhs.rect.centerX - (minX + maxX) / 2,
                                      rhs.rect.centerY - (minY + maxY) / 2)
                    return left < right
                }
                : nil
            let nearbyRecognized: VisionRecognizedText? = nearbyReadout == nil && ordered.count > 1
                ? recognizedText.filter { recognized in
                    guard let display = recognized.text.display,
                          !claimedRecognizedKeys.contains(display.lowercased()),
                          let rect = recognized.rect,
                          let percent = Self.visiblePercent(in: display),
                          segmentProportions.contains(where: { abs($0 - percent) <= 3 }) else {
                        return false
                    }
                    return closeEnough(rect)
                }.min { lhs, rhs in
                    guard let leftRect = lhs.rect, let rightRect = rhs.rect else { return false }
                    let left = hypot(leftRect.centerX - (minX + maxX) / 2,
                                     leftRect.centerY - (minY + maxY) / 2)
                    let right = hypot(rightRect.centerX - (minX + maxX) / 2,
                                      rightRect.centerY - (minY + maxY) / 2)
                    return left < right
                }
                : nil
            let text: String
            if let nearbyReadout, let display = nearbyReadout.text.display {
                claimedReadoutHandles.insert(nearbyReadout.handle)
                text = "\(display) — \(geometry)"
            } else if let nearbyRecognized, let display = nearbyRecognized.text.display {
                claimedRecognizedKeys.insert(display.lowercased())
                text = "\(display) — \(geometry)"
            } else {
                text = geometry
            }
            let confidence = ordered.map { Self.physicalPointConfidence(rows[$0]) }.max() ?? 0
            values.append(MacScreenRender.Value(
                text: MacScreenText(text, redacted: .string(text)),
                provenance: .vision(confidence)
            ))
        }
        return VisionLinearIndicatorRender(
            values: values,
            claimedReadoutHandles: claimedReadoutHandles,
            claimedRecognizedKeys: claimedRecognizedKeys
        )
    }

    private static func naturalShapeNames(_ row: VisionAffordanceRow) -> [String] {
        let noun: String? = switch row.visualShape {
        case "square": "square"
        case "round": "circle"
        default: nil
        }
        guard let noun else { return [] }
        return row.visualColor.map { ["\($0) \(noun)", noun] } ?? [noun]
    }

    static func visiblePercent(in text: String) -> Int? {
        guard let marker = text.firstIndex(of: "%") else { return nil }
        let prefix = text[..<marker]
        let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }

    static func isStandaloneOCRNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers: Set<Character> = ["•", "·", "●", "○", "▪", "▫"]
        let compact = trimmed.filter { !$0.isWhitespace }
        return !compact.isEmpty && compact.allSatisfy { markers.contains($0) }
    }

    /// A bounded minimum-spanning scene graph gives the model relative layout
    /// without repeating every pair or asking it to compare coordinate tuples.
    /// Only stable live identities participate, and HUD values keep priority.
    fileprivate static func spatialRelationValues(
        in rows: [VisionAffordanceRow],
        indexes: Set<Int>,
        frameSize: VisionSize,
        identities: [VisionRect: VisionLiveRegionIdentity]
    ) -> [MacScreenRender.Value] {
        let nodes = indexes.compactMap { index -> VisionSpatialNode? in
            let row = rows[index]
            guard let identity = identities[row.rect] else { return nil }
            return VisionSpatialNode(
                id: identity.id,
                color: row.visualColor,
                shape: row.visualShape,
                rect: row.rect,
                confidence: Self.physicalPointConfidence(row)
            )
        }.sorted { $0.id < $1.id }
        guard nodes.count >= 2, frameSize.width > 0, frameSize.height > 0 else { return [] }

        var connected: Set<Int> = [0]
        var remaining = Set(1..<nodes.count)
        var values: [MacScreenRender.Value] = []
        while !remaining.isEmpty, values.count < 4 {
            var best: (from: Int, to: Int, distance: Double)?
            for from in connected.sorted() {
                for to in remaining.sorted() {
                    let dx = (nodes[to].rect.centerX - nodes[from].rect.centerX) / frameSize.width
                    let dy = (nodes[to].rect.centerY - nodes[from].rect.centerY) / frameSize.height
                    let distance = hypot(dx, dy)
                    if best == nil || distance < best!.distance {
                        best = (from, to, distance)
                    }
                }
            }
            guard let best else { break }
            let source = nodes[best.from]
            let target = nodes[best.to]
            let dx = (target.rect.centerX - source.rect.centerX) / frameSize.width
            let dy = (target.rect.centerY - source.rect.centerY) / frameSize.height
            let overlap = source.rect.iou(target.rect) >= 0.05
                || source.rect.coverage(by: target.rect) >= 0.15
                || target.rect.coverage(by: source.rect) >= 0.15
            let direction: String
            if overlap {
                direction = "overlaps"
            } else if abs(dx) >= abs(dy) {
                direction = dx >= 0 ? "left of" : "right of"
            } else {
                direction = dy >= 0 ? "above" : "below"
            }
            let proximity = !overlap && best.distance <= 0.18 ? "near and " : ""
            func label(_ node: VisionSpatialNode) -> String {
                let appearance = [node.shape, node.color].compactMap { $0 }.joined(separator: " ")
                return appearance.isEmpty
                    ? "visual region \(node.id)"
                    : "\(appearance) visual region \(node.id)"
            }
            let relation = overlap ? direction : "is \(proximity)\(direction)"
            let text = "\(label(source)) \(relation) \(label(target))"
            values.append(MacScreenRender.Value(
                text: MacScreenText(text, redacted: .string(text)),
                provenance: .vision(min(source.confidence, target.confidence))
            ))
            connected.insert(best.to)
            remaining.remove(best.to)
        }
        return values
    }

    /// Confidence shown for a role-uncertain physical object answers the only
    /// claim that row makes: whether its visible point is well pinned. Semantic
    /// target confidence intentionally includes role/label uncertainty and is
    /// therefore the wrong number for an explicitly physical-only address.
    static func physicalPointConfidence(_ row: VisionAffordanceRow) -> Double {
        min(row.confidence.bounds, max(row.salience, row.visualContrast ?? 0))
    }
}
